class MessagesController < ApplicationController
  guard_feature unless: -> { Current.user.ai_enabled? }

  before_action :set_chat

  def create
    content = message_params[:content].to_s.strip

    if content.blank?
      redirect_to chat_path(@chat), alert: "Message content can't be blank" and return
    end

    # ✅ Use latest Gemini model (configurable via .env)
    selected_model = ENV.fetch("GEMINI_DEFAULT_MODEL", "gemini-2.5-pro")

    @message = UserMessage.create!(
      chat: @chat,
      content: content,
      ai_model: selected_model
    )

    redirect_to chat_path(@chat, thinking: true)
  end

  private

  def set_chat
    @chat = Current.user.chats.find(params[:chat_id])
  end

  def message_params
    params.require(:message).permit(:content, :ai_model)
  end
end
