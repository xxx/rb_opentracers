class RbOpentracers::Reporter::Zipkin

  # https://github.com/opentracing/specification/blob/master/data_conventions.yaml
  # https://github.com/openzipkin/zipkin-api/blob/master/thrift/zipkinCore.thrift

  BATCH_SIZE = 100
  OVERFLOW_SIZE = 100
  FLUSH_TIMEOUT = 30

  ZIPKIN_RESPONSE_SUCCESS = 202

  ZIPKIN_DEFAULT = 'http://localhost:9411'

  SERVICE_DEFAULT = {
    serviceName: 'My Service',
    ipv4: '127.0.0.1',
    port: 3000
  }.freeze

  def initialize(
    zipkin_endpoint: ZIPKIN_DEFAULT,
    service: SERVICE_DEFAULT,
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

    @zipkin_endpoint = zipkin_endpoint
    @service_endpoint = service

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
          spans << span
          flush if spans.length >= @batch_size
        end

        s.take(@flushchan) do
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
          @started = false
          flush_timer.shutdown if flush_timer
          if spans.length > 0
            flushable_spans = spans
            spans = []
            flush_spans(flushable_spans)
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

    json = spans.map do |span|
      span_as_json(span)
    end

    json = JSON.dump(json)

    response = RestClient.post "#{@zipkin_endpoint}/api/v1/spans", json, {content_type: :json}
    if response.code != ZIPKIN_RESPONSE_SUCCESS
      log "Unable to post to Zipkin. #{spans.length} spans have been discarded. code: #{response.code} | body: #{response.body}", :warn
    end
  end

  def span_as_json(span)
    ctx = span[:span_context]
    start_microsec = time_to_microsec(span[:start_time])
    end_microsec = time_to_microsec(span[:end_time])

    binaries = span[:tags].map do |key, val|
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

    annotations = span[:log_entries].map do |entry|
      {
        endpoint: @service_endpoint,
        value: entry[:event],
        timestamp: time_to_microsec(entry[:timestamp])
      }
    end

    {
      name: span[:operation_name],
      id: to_id(ctx.id),
      traceId: to_id(ctx.trace_id),
      parentId: to_id(ctx.parent_id),
      timestamp: start_microsec,
      duration: end_microsec - start_microsec,
      annotations: annotations,
      binaryAnnotations: binaries,
      debug: !!span[:tags][:debug]
    }
  end

  def time_to_microsec(t)
    (t.to_f * 1_000_000).to_i
  end

  def log(msg, log_level = :debug)
    if @logger
      @logger.send(log_level, "Zipkin Reporter: #{msg}")
    end
  end

  def to_id(bytes)
    stubs = []
    bytes.chars.each_slice(8) do |a|
      stubs << a.join.unpack('Q')[0].to_s(16)
    end

    stubs.join
  end
end
