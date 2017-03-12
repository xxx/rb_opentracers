class RbOpentracers::Reporter::Appdash
  BATCH_SIZE = 100
  OVERFLOW_SIZE = 100
  FLUSH_TIMEOUT = 30

  APPDASH_DEFAULT = 'localhost:7701'

  def initialize(
    appdash_endpoint: APPDASH_DEFAULT,
    batch_size: BATCH_SIZE,
    overflow_size: OVERFLOW_SIZE,
    flush_timeout: FLUSH_TIMEOUT,
    logger: nil
  )

    @spanchan = Concurrent::Channel.new(capacity: overflow_size)
    # flushchan needs to be buffered, due to us both listening and
    # sending messages to it from within a single .select block
    @flushchan = Concurrent::Channel.new(capacity: 1)
    @clearchan = Concurrent::Channel.new
    @stopchan = Concurrent::Channel.new

    @appdash_endpoint = appdash_endpoint

    h, p = @appdash_endpoint.split(':')
    @socket = TCPSocket.new h, p

    @batch_size = batch_size

    @logger = logger

    @flush_timeout = flush_timeout

    @mutex = Mutex.new

    @started = false
  end

  def register(span)
    # We use offer here, since we don't want to block if spanchan is full.
    # Spans would instead be dropped in that case.
    @spanchan.offer span
  end

  def start
    @mutex.synchronize do
      return if @started
      @started = true
    end

    spans = []

    flush_timer = nil
    if @flush_timeout
      flush_timer = Concurrent::TimerTask.new(execution_interval: @flush_timeout) do
        flush
      end

      flush_timer.execute
    end

    Concurrent::Channel.go_loop do
      continue = true

      Concurrent::Channel.select do |s|
        s.take(@spanchan) do |span|
          puts "recd"
          spans << span
          flush if spans.length >= @batch_size
        end

        s.take(@flushchan) do
          puts "flushing"
          if spans.length > 0
            flushable_spans = spans
            spans = []
            Concurrent::Channel.go { flush_spans(flushable_spans) }
          end
        end

        s.take(@clearchan) do
          spans = []
        end

        s.take(@stopchan) do
          begin
            @started = false
            flush_timer.shutdown if flush_timer
            if spans.length > 0
              flushable_spans = spans
              spans = []
              flush_spans(flushable_spans)
            end
          ensure
            @socket.close
          end

          continue = false
        end
      end

      continue
    end
  end

  def flush
    @flushchan.offer 0
  end

  def clear
    @clearchan << 0
  end

  def stop
    @stopchan << 0
  end

  private

  def flush_spans(spans)
    # This should only be called from within an existing critical section,
    # so no need to mutex.

    pb = spans.map do |span|
      begin
        packet = span_as_pb(span)
        p packet.bytes, packet.bytes.length

        encode_varint(packet.bytesize) + packet
        # packet
      rescue Exception => e
        puts "exception in flush_spans: #{e}"
      end
    end.compact

    puts "flushing spans"
    p pb.first, pb.first.bytes
    # @socket.write pb.join("\n")
    @socket.write pb.first
  end

  def span_as_pb(event)
    ctx = event[:span_context]

    # Cut the default 128 bit trace ids down to 64
    trace_id = ctx.trace_id.unpack('Q<')[0]
    log "trace id: #{trace_id} #{trace_id.to_s(16)} #{trace_id.class}"
    span_id = ctx.id.unpack('Q<')[0]
    parent_id = if ctx.parent_id
                  ctx.parent_id.unpack('Q<')[0]
                else
                  nil
                end
    # wired = PBuf::CollectPacket::SpanID.new(trace: trace_id, span: span_id)
    wired = PBuf::CollectPacket::SpanID.new(trace: trace_id, span: span_id, parent: parent_id)
    annotation = PBuf::CollectPacket::Annotation.new(key: "some event", value: "hello")
    # annotation = PBuf::CollectPacket::Annotation.new(key: "some event", value: nil)
    unencoded = PBuf::CollectPacket.new(SpanID: wired, Annotation: [annotation])
    log PBuf::CollectPacket.encode_json(unencoded)
    encoded = PBuf::CollectPacket.encode(unencoded)
    p 'encoded:', encoded
    p 'decoded:', PBuf::CollectPacket.decode(encoded)
    encoded
  end

  def span_as_json(event)
    ctx = event[:span_context]
    start_microsec = time_to_microsec(event[:start_time])
    end_microsec = time_to_microsec(event[:end_time])

    binaries = event[:tags].map do |key, val|
      {
        endpoint: @service_endpoint,
        key: key.to_s,
        value: val.to_s
      }
    end

    ctx.baggage.each do |key, val|
      binaries << {
        endpoint: @service_endpoint,
        key: "bg:#{key}",
        value: val.to_s
      }
    end

    # Eh. This has to be wrong.
    annotations = event[:log_entries].map do |entry|
      {
        endpoint: @service_endpoint,
        value: entry[:event],
        timestamp: time_to_microsec(entry[:timestamp])
      }
    end

    {
      name: event[:operation_name],
      id: ctx.id,
      traceId: ctx.trace_id,
      parentId: ctx.parent_id,
      timestamp: start_microsec,
      duration: end_microsec - start_microsec,
      annotations: annotations,
      binaryAnnotations: binaries,
      debug: !!event[:tags][:debug]
    }
  end

  def time_to_microsec(t)
    (t.to_f * 1_000_000).to_i
  end

  def log(msg, log_level = :debug)
    if @logger
      @logger.send(log_level, "Appdash Reporter: #{msg}")
    end
  end

  def encode_varint(int_val)
    r = ''
    r.force_encoding(Encoding::BINARY)

    if int_val < 0
      # negative varints are always encoded with the full 10 bytes
      int_val = int_val & 0xffffffff_ffffffff
    end
    loop do
      byte = int_val & 0b0111_1111
      int_val >>= 7
      if int_val == 0
        r << byte.chr
        break
      else
        r << (byte | 0b1000_0000).chr
      end
    end
    r
  end

  # This is built from a v3-compatible .proto file, included in the repo.

  module PBuf
    Google::Protobuf::DescriptorPool.generated_pool.build do
      add_message "appdash.CollectPacket" do
        optional :SpanID, :message, 1, "appdash.CollectPacket.SpanID"
        repeated :Annotation, :message, 5, "appdash.CollectPacket.Annotation"
      end
      add_message "appdash.CollectPacket.SpanID" do
        optional :trace, :fixed64, 2
        optional :span, :fixed64, 3
        optional :parent, :fixed64, 4
      end
      add_message "appdash.CollectPacket.Annotation" do
        optional :key, :string, 6
        optional :value, :bytes, 7
      end
    end

    CollectPacket = Google::Protobuf::DescriptorPool.generated_pool.lookup("appdash.CollectPacket").msgclass
    CollectPacket::SpanID = Google::Protobuf::DescriptorPool.generated_pool.lookup("appdash.CollectPacket.SpanID").msgclass
    CollectPacket::Annotation = Google::Protobuf::DescriptorPool.generated_pool.lookup("appdash.CollectPacket.Annotation").msgclass
  end
end
