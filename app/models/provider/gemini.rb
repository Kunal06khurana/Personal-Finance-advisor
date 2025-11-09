class Provider::Gemini < Provider
  include LlmConcept

  # Subclass so errors caught in this provider are raised as Provider::Gemini::Error
  Error = Class.new(Provider::Error)

  # ✅ Added support for gemini-2.5 models
  MODELS = %w[
    gemini-2.5-pro
    gemini-1.5-pro
    gemini-2.0-flash
    gemini-2.0-pro
    gemini-2.5-flash
    gemini-2.5-pro
  ]

  def initialize(api_key = ENV["GEMINI_API_KEY"])
    raise Error, "Missing Gemini API key" if api_key.blank?

    @api_key = api_key
    @http = Faraday.new(url: "https://generativelanguage.googleapis.com") do |f|
      f.request :json
      f.response :json, content_type: /json/
      f.adapter Faraday.default_adapter
    end
  end

  def supports_model?(model)
    MODELS.include?(model)
  end

  # ✅ Handles Gemini chat responses
  def chat_response(prompt, model:, instructions: nil, functions: [], function_results: [], streamer: nil, previous_response_id: nil)
    with_provider_response do
      # Gemini expects message structure in "contents"
      request_body = {
        contents: [
          { role: "user", parts: [{ text: prompt }] }
        ]
      }

      # ✅ Add system instruction (Gemini uses camelCase key)
      if instructions.present?
        request_body[:systemInstruction] = { role: "system", parts: [{ text: instructions }] }
      end

      # ✅ Debugging info (optional - remove after testing)
      puts ">>> [Gemini] Sending request to model: #{model}"
      puts ">>> [Gemini] Request body: #{request_body.to_json}"

      # ✅ Corrected API endpoint (uses ?key=)
      response = @http.post(
        "/v1beta/models/#{model}:generateContent?key=#{@api_key}",
        request_body,
        { "Content-Type" => "application/json" }
      )

      unless response.success?
        raise Error.new("Gemini API error", details: response.body)
      end

      # ✅ Parse the Gemini response
      data = response.body
      candidate = Array(data["candidates"]).first
      content = candidate && candidate["content"]
      parts = Array(content && content["parts"])
      text = parts.map { |p| p["text"] }.compact.join

      # ✅ Build ChatResponse
      output_message = ChatMessage.new(SecureRandom.uuid, text)
      concept_response = ChatResponse.new(
        SecureRandom.uuid,
        model,
        [output_message],
        []
      )

      # ✅ Support streaming if applicable
      if streamer.present?
        streamer.call(ChatStreamChunk.new("output_text", text)) if text.present?
        streamer.call(ChatStreamChunk.new("response", concept_response))
      end

      concept_response
    end
  end

  private

  attr_reader :api_key
end
