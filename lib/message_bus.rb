require "monitor"
require "set"
require "message_bus/version"
require "message_bus/message"
require "message_bus/client"
require "message_bus/connection_manager"
require "message_bus/message_handler"
require "message_bus/diagnostics"
require "message_bus/rack/middleware"
require "message_bus/rack/diagnostics"
require "message_bus/redis/reliable_pub_sub"
require "message_bus/timer_thread"

# we still need to take care of the logger
if defined?(::Rails)
  require 'message_bus/rails/railtie'
end

module MessageBus; end
class MessageBus::InvalidMessage < StandardError; end
class MessageBus::BusDestroyed < StandardError; end

module MessageBus::Implementation

  # Like Mutex but safe for recursive calls
  class Synchronizer
    include MonitorMixin
  end

  def initialize
    @mutex = Synchronizer.new
  end

  def cache_assets=(val)
    @cache_assets = val
  end

  def cache_assets
    if defined? @cache_assets
      @cache_assets
    else
      true
    end
  end

  def logger=(logger)
    @logger = logger
  end

  def logger
    return @logger if @logger
    require 'logger'
    @logger = Logger.new(STDOUT)
  end

  def long_polling_enabled?
    @long_polling_enabled == false ? false : true
  end

  def long_polling_enabled=(val)
    @long_polling_enabled = val
  end

  # The number of simultanuous clients we can service
  #  will revert to polling if we are out of slots
  def max_active_clients=(val)
    @max_active_clients = val
  end

  def max_active_clients
    @max_active_clients || 1000
  end

  def rack_hijack_enabled?
    if @rack_hijack_enabled.nil?
      @rack_hijack_enabled = true

      # without this switch passenger will explode
      # it will run out of connections after about 10
      if defined? PhusionPassenger
        @rack_hijack_enabled = false
        if PhusionPassenger.respond_to? :advertised_concurrency_level
          PhusionPassenger.advertised_concurrency_level = 0
          @rack_hijack_enabled = true
        end
      end
    end

    @rack_hijack_enabled
  end

  def rack_hijack_enabled=(val)
    @rack_hijack_enabled = val
  end

  def long_polling_interval=(millisecs)
    @long_polling_interval = millisecs
  end

  def long_polling_interval
    @long_polling_interval || 25 * 1000
  end

  def off
    @off = true
  end

  def on
    @off = false
  end

  # Allow us to inject a redis db
  def redis_config=(config)
    @redis_config = config
  end

  def redis_config
    @redis_config ||= {}
  end

  def site_id_lookup(&blk)
    @site_id_lookup = blk if blk
    @site_id_lookup
  end

  def user_id_lookup(&blk)
    @user_id_lookup = blk if blk
    @user_id_lookup
  end

  def group_ids_lookup(&blk)
    @group_ids_lookup = blk if blk
    @group_ids_lookup
  end

  def is_admin_lookup(&blk)
    @is_admin_lookup = blk if blk
    @is_admin_lookup
  end

  def extra_response_headers_lookup(&blk)
    @extra_response_headers_lookup = blk if blk
    @extra_response_headers_lookup
  end

  def client_filter(channel, &blk)
    @client_filters ||= {}
    @client_filters[channel] = blk if blk
    @client_filters[channel]
  end

  def around_client_batch(channel, &blk)
    @around_client_batches ||= {}
    @around_client_batches[channel] = blk if blk
    @around_client_batches[channel]
  end

  def on_connect(&blk)
    @on_connect = blk if blk
    @on_connect
  end

  def on_disconnect(&blk)
    @on_disconnect = blk if blk
    @on_disconnect
  end

  def allow_broadcast=(val)
    @allow_broadcast = val
  end

  def allow_broadcast?
    @allow_broadcast ||=
      if defined? ::Rails
        ::Rails.env.test? || ::Rails.env.development?
      else
        false
      end
  end

  def reliable_pub_sub=(pub_sub)
    @reliable_pub_sub = pub_sub
  end

  def reliable_pub_sub
    @mutex.synchronize do
      return nil if @destroyed
      @reliable_pub_sub ||= MessageBus::Redis::ReliablePubSub.new redis_config
    end
  end

  def enable_diagnostics
    MessageBus::Diagnostics.enable
  end

  def publish(channel, data, opts = nil)
    return if @off
    @mutex.synchronize do
      raise ::MessageBus::BusDestroyed if @destroyed
    end

    user_ids = nil
    group_ids = nil
    client_ids = nil

    if opts
      user_ids = opts[:user_ids]
      group_ids = opts[:group_ids]
      client_ids = opts[:client_ids]
    end

    raise ::MessageBus::InvalidMessage if (user_ids || group_ids) && global?(channel)

    encoded_data = JSON.dump({
      data: data,
      user_ids: user_ids,
      group_ids: group_ids,
      client_ids: client_ids
    })

    reliable_pub_sub.publish(encode_channel_name(channel), encoded_data)
  end

  def blocking_subscribe(channel=nil, &blk)
    if channel
      reliable_pub_sub.subscribe(encode_channel_name(channel), &blk)
    else
      reliable_pub_sub.global_subscribe(&blk)
    end
  end

  ENCODE_SITE_TOKEN = "$|$"

  # encode channel name to include site
  def encode_channel_name(channel, site_id=nil)
    if (site_id || site_id_lookup) && !global?(channel)
      raise ArgumentError.new channel if channel.include? ENCODE_SITE_TOKEN
      "#{channel}#{ENCODE_SITE_TOKEN}#{site_id || site_id_lookup.call}"
    else
      channel
    end
  end

  def decode_channel_name(channel)
    channel.split(ENCODE_SITE_TOKEN)
  end

  def subscribe(channel=nil, &blk)
    subscribe_impl(channel, nil, &blk)
  end

  def unsubscribe(channel=nil, &blk)
    unsubscribe_impl(channel, nil, &blk)
  end

  def local_unsubscribe(channel=nil, &blk)
    site_id = site_id_lookup.call if site_id_lookup
    unsubscribe_impl(channel, site_id, &blk)
  end

  # subscribe only on current site
  def local_subscribe(channel=nil, &blk)
    site_id = site_id_lookup.call if site_id_lookup && ! global?(channel)
    subscribe_impl(channel, site_id, &blk)
  end

  def global_backlog(last_id=nil)
    backlog(nil, last_id)
  end

  def backlog(channel=nil, last_id=nil, site_id=nil)
    old =
      if channel
        reliable_pub_sub.backlog(encode_channel_name(channel,site_id), last_id)
      else
        reliable_pub_sub.global_backlog(last_id)
      end

    old.each{ |m|
      decode_message!(m)
    }
    old
  end

  def last_id(channel,site_id=nil)
    reliable_pub_sub.last_id(encode_channel_name(channel,site_id))
  end

  def last_message(channel)
    if last_id = last_id(channel)
      messages = backlog(channel, last_id-1)
      if messages
        messages[0]
      end
    end
  end

  def destroy
    @mutex.synchronize do
      @subscriptions ||= {}
      reliable_pub_sub.global_unsubscribe
      @destroyed = true
    end
    @subscriber_thread.join if @subscriber_thread
    timer.stop
  end

  def after_fork
    reliable_pub_sub.after_fork
    ensure_subscriber_thread
    # will ensure timer is running
    timer.queue{}
  end

  def listening?
    @subscriber_thread && @subscriber_thread.alive?
  end

  # will reset all keys
  def reset!
    reliable_pub_sub.reset!
  end

  def timer
    return @timer_thread if @timer_thread
    @timer_thread ||= begin
      t = MessageBus::TimerThread.new
      t.on_error do |e|
        logger.warn "Failed to process job: #{e} #{e.backtrace}"
      end
      t
    end
  end

  # set to 0 to disable, anything higher and
  # a keepalive will run every N seconds, if it fails
  # process is killed
  def keepalive_interval=(interval)
    @keepalive_interval = interval
  end

  def keepalive_interval
    @keepalive_interval || 60
  end

  protected

  def global?(channel)
    channel && channel.start_with?('/global/'.freeze)
  end

  def decode_message!(msg)
    channel, site_id = decode_channel_name(msg.channel)
    msg.channel = channel
    msg.site_id = site_id
    parsed = JSON.parse(msg.data)
    msg.data = parsed["data"]
    msg.user_ids = parsed["user_ids"]
    msg.group_ids = parsed["group_ids"]
    msg.client_ids = parsed["client_ids"]
  end

  def subscribe_impl(channel, site_id, &blk)

    raise MessageBus::BusDestroyed if @destroyed

    @subscriptions ||= {}
    @subscriptions[site_id] ||= {}
    @subscriptions[site_id][channel] ||=  []
    @subscriptions[site_id][channel] << blk
    ensure_subscriber_thread

    attempts = 100
    while attempts > 0 && !reliable_pub_sub.subscribed
      sleep 0.001
      attempts-=1
    end

    raise MessageBus::BusDestroyed if @destroyed
    blk
  end

  def unsubscribe_impl(channel, site_id, &blk)

    @mutex.synchronize do
      if blk
        @subscriptions[site_id][channel].delete blk
      else
        @subscriptions[site_id][channel] = []
      end
    end

  end


  def ensure_subscriber_thread
    @mutex.synchronize do
      return if (@subscriber_thread && @subscriber_thread.alive?) || @destroyed
      @subscriber_thread = new_subscriber_thread
    end
  end

  MIN_KEEPALIVE = 20

  def new_subscriber_thread

    thread = Thread.new do
      begin
        global_subscribe_thread unless @destroyed
      rescue => e
        MessageBus.logger.warn "Unexpected error in subscriber thread #{e}"
      end
    end

    # adjust for possible race condition
    @last_message = Time.now

    blk = proc do
      if !@destroyed && thread.alive? && keepalive_interval > MIN_KEEPALIVE

        publish("/__mb_keepalive__/", Process.pid, user_ids: [-1])
        # going for x3 keepalives missed for a restart, need to ensure this only very rarely happens
        # note: after_fork will sort out a bad @last_message date, but thread will be dead anyway
        if (Time.now - (@last_message || Time.now)) > keepalive_interval*3
          MessageBus.logger.warn "Global messages on #{Process.pid} timed out, restarting process"
          # No other clean way to remove this thread, its listening on a socket
          #   no data is arriving
          #
          # In production we see this kind of situation ... sometimes ... when there is
          # a VRRP failover, or weird networking condition
          pid = Process.pid

          # do the best we can to terminate self cleanly
          fork do
            Process.kill('TERM', pid)
            sleep 10
            Process.kill('KILL', pid)
          end

          sleep 10
          Process.kill('KILL', pid)

        else
          timer.queue(keepalive_interval, &blk) if keepalive_interval > MIN_KEEPALIVE
        end
      end
    end

    timer.queue(keepalive_interval, &blk) if keepalive_interval > MIN_KEEPALIVE

    thread
  end

  def global_subscribe_thread
    # pretend we just got a message
    @last_message = Time.now
    reliable_pub_sub.global_subscribe do |msg|
      begin
        @last_message = Time.now
        decode_message!(msg)
        globals, locals, local_globals, global_globals = nil

        @mutex.synchronize do
          raise MessageBus::BusDestroyed if @destroyed
          @subscriptions ||= {}
          globals = @subscriptions[nil]
          locals = @subscriptions[msg.site_id] if msg.site_id

          global_globals = globals[nil] if globals
          local_globals = locals[nil] if locals

          globals = globals[msg.channel] if globals
          locals = locals[msg.channel] if locals
        end

        multi_each(globals,locals, global_globals, local_globals) do |c|
          begin
            c.call msg
          rescue => e
            MessageBus.logger.warn "failed to deliver message, skipping #{msg.inspect}\n ex: #{e} backtrace: #{e.backtrace}"
          end
        end
      rescue => e
        MessageBus.logger.warn "failed to process message #{msg.inspect}\n ex: #{e} backtrace: #{e.backtrace}"
      end
      @global_id = msg.global_id
    end
  end

  def multi_each(*args,&block)
    args.each do |a|
      a.each(&block) if a
    end
  end

end

module MessageBus
  extend MessageBus::Implementation
  initialize
end

# allows for multiple buses per app
class MessageBus::Instance
  include MessageBus::Implementation
end
