enum WebSocketSystemError: Error {
  case message(String)
  case actorNotFound(Address)
  case invalidMessage
}
