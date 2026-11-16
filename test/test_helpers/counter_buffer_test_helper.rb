require "socket"

# Tests of the Valkey counter buffer (Ingest::CounterBuffer) run against a
# real store when REDIS_URL is set (CI runs a Valkey service), and skip
# otherwise. Each test gets its own key namespace, so parallel workers never
# share keys, and its keys are deleted afterwards. The app itself never
# buffers in test (config.x.counter_buffer_url is nil).
module CounterBufferTestHelper
  # A TCP proxy in front of the store that holds back the reply to the
  # first command containing +delay_command+ (which has run in the store by
  # then) for +delay+ seconds, and counts the commands containing +count+.
  # Deterministic as long as each command arrives in one read, which small
  # commands on localhost do.
  class DelayingProxy
    attr_reader :port

    def initialize(upstream_host, upstream_port, delay_command:, delay:, count: delay_command)
      @upstream = [ upstream_host, upstream_port ]
      @delay_command, @delay, @count = delay_command, delay, count
      @counted = 0
      @mutex = Mutex.new
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @threads = [ Thread.new { accept_loop } ]
    end

    def counted = @mutex.synchronize { @counted }

    def close
      @server.close
      @threads.each(&:kill)
    end

    private
      def accept_loop
        loop do
          client = @server.accept
          @threads << Thread.new { relay(client) }
        end
      rescue IOError, Errno::EBADF
        nil
      end

      def relay(client)
        upstream = TCPSocket.new(*@upstream)
        delays = Queue.new
        @threads << Thread.new { forward_commands(client, upstream, delays) }
        forward_replies(upstream, client, delays)
      ensure
        [ client, upstream ].compact.each { |socket| socket.close unless socket.closed? }
      end

      def forward_commands(client, upstream, delays)
        loop do
          data = client.readpartial(65_536)
          note(data, delays)
          upstream.write(data)
        end
      rescue IOError, SystemCallError
        upstream.close unless upstream.closed?
      end

      def note(data, delays)
        @mutex.synchronize do
          @counted += 1 if data.include?(@count)
          next if @delayed || !data.include?(@delay_command)

          @delayed = true
          delays << true
        end
      end

      def forward_replies(upstream, client, delays)
        loop do
          data = upstream.readpartial(65_536)
          sleep @delay if !delays.empty? && delays.pop
          client.write(data)
        end
      rescue IOError, SystemCallError
        nil
      end
  end

  def counter_store_url = ENV["REDIS_URL"].presence

  def counter_pool
    skip "set REDIS_URL to run the counter buffer tests against Valkey" unless counter_store_url
    Ingest::CounterBuffer.connect(counter_store_url)
  end

  def counter_namespace = @counter_namespace ||= "test:counters:#{SecureRandom.hex(8)}"

  def counter_buffer(chunk_rows: Ingest::CounterBuffer::CHUNK_ROWS, pool: counter_pool)
    Ingest::CounterBuffer.new(pool, namespace: counter_namespace, chunk_rows:, breaker: Ingest::CounterStoreBreaker.new)
  end

  # A buffer whose connections go through a DelayingProxy, built with the
  # production client options except a short read timeout.
  def proxied_counter_buffer(proxy)
    counter_pool
    url = URI(counter_store_url).tap { |uri| uri.host, uri.port = "127.0.0.1", proxy.port }.to_s
    pool = ConnectionPool.new(size: 1) { Redis.new(url:, **Ingest::CounterBuffer::CLIENT_OPTIONS, read_timeout: 0.2) }
    counter_buffer(pool:)
  end

  def delaying_proxy(**options)
    uri = URI(counter_store_url || skip("set REDIS_URL to run the counter buffer tests against Valkey"))
    DelayingProxy.new(uri.host, uri.port || 6379, **options)
  end

  # Every key the test's buffer wrote, with its type and contents, except
  # the events' guard keys (which expire on their own).
  def counter_store_dump
    counter_pool.with do |redis|
      redis.scan_each(match: "#{counter_namespace}:*").reject { it.include?(":seen:") }.to_h { |key| [ key, dump_key(redis, key) ] }
    end
  end

  def counter_seen_keys
    counter_pool.with { |redis| redis.scan_each(match: "#{counter_namespace}:seen:*").to_a }
  end

  def clear_counter_store
    return unless counter_store_url && @counter_namespace

    Ingest::CounterBuffer.connect(counter_store_url).with do |redis|
      redis.scan_each(match: "#{counter_namespace}:*").each { |key| redis.del(key) }
    end
  end

  private
    def dump_key(redis, key)
      case redis.type(key)
      when "hash" then redis.hgetall(key)
      when "set" then redis.smembers(key)
      else redis.get(key)
      end
    end
end
