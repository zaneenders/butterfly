enum WebSocketSystemError: Error {
  case message(String)
  case actorNotFound(EntityAddress)
  case invalidMessage
}
