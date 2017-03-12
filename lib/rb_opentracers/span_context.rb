class RbOpentracers::SpanContext
  attr_reader :baggage, :id, :trace_id
  attr_accessor :parent_id

  # Create a new SpanContext
  # @param id the ID of the Context
  # @param trace_id the ID of the current trace
  # @param baggage baggage
  def initialize(id: generate_id, trace_id:, baggage: {})
    @id = id
    @trace_id = trace_id
    @baggage = baggage
  end

  def set_baggage_item(key, value)
    baggage[key] = value
  end

  def get_baggage_item(key)
    baggage[key]
  end

  private

  def generate_id
    SecureRandom.random_bytes(8)
  end
end
