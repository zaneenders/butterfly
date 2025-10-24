# Butterfly

This repo contains two [DistributedActorSystem](https://developer.apple.com/documentation/distributed/distributedactorsystem), and is more a play ground for me to explore and experiment with the language feature and learn about distributed systems.

### [Butterfly](Sources/Butterfly) 

Currently is a many to many system trying to model nodes in a system, If a node knows the ID/address of an actor on any node it can make remote calls to the actor. 

### [WebSocketSystem](./Sources/WebSocketSystem)
Is more of a client server setup. Where the server can make calls to the client well the connection is up but the client has to initiate the call.


## Testing

View test coverage

```console
swift test --enable-code-coverage

llvm-cov report .build/debug/butterflyPackageTests.xctest --instr-profile=.build/debug/codecov/default.profdata --ignore-filename-regex='(.build|Tests)[/\\].*' 
```

# Deployment 

## [Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html)

Trying to keep the project able to staticly compile for linux.

```
swift build --swift-sdk aarch64-swift-linux-musl
swift build --swift-sdk x86_64-swift-linux-musl
```