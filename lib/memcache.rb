require 'java'
require 'base64'

require File.dirname(__FILE__) + '/java/java_memcached-release_2.5.1.jar'

class MemCache
  include_class 'com.danga.MemCached.MemCachedClient'
  include_class 'com.danga.MemCached.SockIOPool'
  include_class 'com.danga.MemCached.Logger'

  VERSION = '1.7.0'

  ##
  # Default options for the cache object.

  DEFAULT_OPTIONS = {
    :namespace   => nil,
    :readonly    => false,
    :multithread => true,
    :pool_initial_size => 10,
    :pool_min_size => 5,
    :pool_max_size => 100,
    :pool_max_idle => (1000 * 60 * 5),
    :pool_max_busy => (1000 * 30),
    :pool_maintenance_thread_sleep => (1000 * 30),
    :pool_socket_timeout => (1000 * 3),
    :pool_socket_connect_timeout => (1000 * 3),
    :pool_use_alive => false,
    :pool_use_failover => true,
    :pool_use_failback => true,
    :pool_use_nagle => false,
    :pool_name => 'default',
    :log_level => 2
  }

  ## CHARSET for Marshalling
  MARSHALLING_CHARSET = 'UTF-8'

  ##
  # Default memcached port.

  DEFAULT_PORT = 11211

  ##
  # Default memcached server weight.

  DEFAULT_WEIGHT = 1

  attr_accessor :request_timeout

  # TODO: Rails set the logger for MemCache.
  attr_accessor :logger

  attr_reader :silence

  def silence!
    @silence = true
    self
  end

  alias silence? silence

  ##
  # The namespace for this instance

  attr_reader :namespace

  ##
  # The multithread setting for this instance

  attr_reader :multithread

  ##
  # The configured socket pool name for this client.
  attr_reader :pool_name

  ##
  # Configures the client
  def initialize(*args)
    @servers = []
    opts = {}

    case args.length
    when 0 then # NOP
    when 1 then
      arg = args.shift
      case arg
      when Hash   then opts = arg
      when Array  then @servers = arg
      when String then @servers = [arg]
      else raise ArgumentError, 'first argument must be Array, Hash or String'
      end
    when 2 then
      @servers, opts = args
      @servers = [@servers].flatten
    else
      raise ArgumentError, "wrong number of arguments (#{args.length} for 2)"
    end

    # Normalizing the server(s) so they all have a port number.

    @servers = @servers.map do |server|
      server =~ /(.+):(\d+)/ ? server : "#{server}:#{DEFAULT_PORT}"
    end

    Logger.getLogger('com.meetup.memcached.MemcachedClient').setLevel(opts[:log_level])
    Logger.getLogger('com.meetup.memcached.SockIOPool').setLevel(opts[:log_level])

    opts = DEFAULT_OPTIONS.merge opts

    @namespace = opts[:namespace] || opts["namespace"]
    @pool_name = opts[:pool_name] || opts["pool_name"]
    @readonly = opts[:readonly] || opts["readonly"]

    @client = MemCachedClient.new(@pool_name)

    @client.error_handler = opts[:error_handler] if opts[:error_handler]
    @client.primitiveAsString = true
    @client.sanitizeKeys = false

    weights = Array.new(@servers.size, DEFAULT_WEIGHT)

    @pool = SockIOPool.getInstance(@pool_name)
    unless @pool.initialized?
      @pool.servers = @servers.to_java(:string)
      @pool.weights = weights.to_java(:Integer)

      @pool.initConn = opts[:pool_initial_size]
      @pool.minConn = opts[:pool_min_size]
      @pool.maxConn = opts[:pool_max_size]

      @pool.maxIdle = opts[:pool_max_idle]
      @pool.maxBusyTime = opts[:pool_max_busy]
      @pool.maintSleep = opts[:pool_maintenance_thread_sleep]
      @pool.socketTO = opts[:pool_socket_timeout]
      @pool.socketConnectTO = opts[:pool_socket_connect_timeout]

      @pool.failover = opts[:pool_use_failover]
      @pool.failback = opts[:pool_use_failback]
      @pool.aliveCheck = opts[:pool_use_alive]
      @pool.nagle = opts[:pool_use_nagle]

      # public static final int NATIVE_HASH     = 0;
      #     // native String.hashCode();
      # public static final int OLD_COMPAT_HASH = 1;
      #     // original compatibility hashing algorithm (works with other clients)
      # public static final int NEW_COMPAT_HASH = 2;
      #     // new CRC32 based compatibility hashing algorithm (works with other clients)
      # public static final int CONSISTENT_HASH = 3;
      #     // MD5 Based -- Stops thrashing when a server added or removed
      @pool.hashingAlg = opts[:pool_hashing_algorithm]

      # __method methods have been removed in jruby 1.5
      @pool.java_send :initialize rescue @pool.initialize__method
    end

  end

  def reset
    @pool.shut_down
    @pool.java_send :initialize rescue @pool.initialize__method
  end

  ##
  # Returns the servers that the client has been configured to
  # use. Injects an alive? method into the string so it works with the
  # updated Rails MemCacheStore session store class.
  def servers
    @pool.servers.to_a.collect do |s|
      s.instance_eval(<<-EOIE)
      def alive?
        #{!!stats[s]}
      end
      EOIE
      s
    end rescue []
  end

  ##
  # Determines whether any of the connections to the servers is
  # alive. We are alive if it is the case.
  def alive?
    servers.to_a.any? { |s| s.alive? }
  end

  alias :active? :alive?

  ##
  # Retrieves a value associated with the key from the
  # cache. Retrieves the raw value if the raw parameter is set.
  def read(key, options=nil)
    options ||= {}
    value = instrument(:read, key, options) do
      @client.get(make_cache_key(key))
    end
    return nil if value.nil?
    unless options[:raw]
      begin
        marshal_bytes = java.lang.String.new(value).getBytes(MARSHALLING_CHARSET)
        decoded = Base64.decode64(String.from_java_bytes(marshal_bytes))
        value = Marshal.load(decoded)
      rescue
        value = case value
          when /^\d+\.\d+$/ then value.to_f
          when /^\d+$/ then value.to_i
          else value
        end
      end
    end
    value
  end

  ##
  # Retrieves the values associated with the keys parameter.
  def read_multi(keys, options=nil)
    options ||= {}
    keys = keys.map {|k| make_cache_key(k)}
    keys = keys.to_java :String
    values = {}
    values_j = instrument(:read_multi, keys, options) do
      @client.getMulti(keys)
    end
    values_j.to_a.each {|kv|
      k,v = kv
      next if v.nil?
      unless options[:raw]
        begin
          marshal_bytes = java.lang.String.new(v).getBytes(MARSHALLING_CHARSET)
          decoded = Base64.decode64(String.from_java_bytes(marshal_bytes))
          v = Marshal.load(decoded)
        rescue
          v = case v
            when /^\d+\.\d+$/ then v.to_f
            when /^\d+$/ then v.to_i
            else v
          end
        end
      end
      values[k] = v
    }
    values
  end

  ##
  # Associates a value with a key in the cache. MemCached will expire
  # the value if an expiration is provided. The raw parameter allows
  # us to store a value without marshalling it first.
  def write(key, value, options=nil)
    raise MemCacheError, "Update of readonly cache" if @readonly
    options ||= {}
    options[:expires_in] ||= 0
    method = write_method(options)
    value = marshal_value(value) unless options[:raw]
    key = make_cache_key(key)
    instrument(:write, method, options) do
      if options[:expires_in] == 0
        @client.send method, key, value
      else
        @client.send method, key, value, expiration(options[:expires_in])
      end
    end
  end

  ##
  # Retrieves a value associated with the key from the
  # cache, if the key is not existed, associates the block value
  # with the key int eh cache.
  def fetch(key, options=nil)
    options ||= {}
    key = make_cache_key(key)
    if block_given?
      unless options[:force]
        value = read(key, options)
      end
      if !value.nil?
        value
      else
        value = yield
        write(key, value, options)
        value
      end
    else
      read(key, options)
    end
  end

  ##
  # Removes the value associated with the key from the cache. This
  # will ignore values that are not already present in the cache,
  # which makes this safe to use without first checking for the
  # existance of the key in the cache first.
  def delete(key, options=nil)
    raise MemCacheError, "Update of readonly cache" if @readonly
    options ||= {}
    instrument(:delete, key, options) do
      @client.delete(make_cache_key(key))
    end
  end

  ##
  # Checks if the key already exists.
  def exist?(key)
    instrument(:exist?, key) do
      @client.key_exists?(make_cache_key(key))
    end
  end

  ##
  # Increments the value associated with the key by a certain amount.
  def incr(key, amount = 1)
    raise MemCacheError, "Update of readonly cache" if @readonly
    value = instrument(:incr, key, amount) do
      @client.incr(make_cache_key(key), amount)
    end
    return nil if value == "NOT_FOUND\r\n"
    return value.to_i
  end

  ##
  # Decrements the value associated with the key by a certain amount.
  def decr(key, amount = 1)
    raise MemCacheError, "Update of readonly cache" if @readonly
    value = instrument(:decr, key, amount) do
      @client.decr(make_cache_key(key),amount)
    end
    return nil if value == "NOT_FOUND\r\n"
    return value.to_i
  end

  ##
  # Clears the cache.
  def flush_all
    @client.flush_all
  end

  ##
  # Reports statistics on the cache.
  def stats
    stats_hash = {}
    @client.stats.each do |server, stats|
      stats_hash[server] = Hash.new
      stats.each do |key, value|
        unless key == 'version'
          value = value.to_f
          value = value.to_i if value == value.ceil
        end
        stats_hash[server][key] = value
      end
    end
    stats_hash
  end

  class MemCacheError < RuntimeError; end

  protected
  def make_cache_key(key)
    if namespace.nil? then
      key
    else
      "#{@namespace}:#{key}"
    end
  end

  def expiration(expiry)
    java.util.Date.new((Time.now.to_i + expiry) * 1000)
  end

  def marshal_value(value)
    return value if value.kind_of?(Numeric)
    encoded = Base64.encode64(Marshal.dump(value))
    marshal_bytes = encoded.to_java_bytes
    java.lang.String.new(marshal_bytes, MARSHALLING_CHARSET)
  end

  def write_method(options={})
    if options[:unless_exist]
      :add
    elsif options[:if_exist]
      :replace
    else
      :set
    end
  end

  def instrument(operation, key, options=nil)
    logger.debug("Cache #{operation}: #{key}#{options ? " (#{options.inspect})" : ""}") if logger && !silence?

    yield
  end
end
