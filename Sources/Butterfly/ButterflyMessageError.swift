enum ButterflyMessageError: Error, Equatable {
  case idk(String)
  case networking(String)
  case decoding(String)
  case returnNameManglingError
}
