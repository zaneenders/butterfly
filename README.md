# Butterfly

## Testing

View test coverage

```console
swift test --enable-code-coverage

llvm-cov report .build/debug/butterflyPackageTests.xctest --instr-profile=.build/debug/codecov/default.profdata --ignore-filename-regex='(.build|Tests)[/\\].*' 
```

## Development

Generate testing keys.

```
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes
```