# Butterfly

## Testing

Run the test with SSL enabled

```
swift test --traits SSL
```

View test coverage

```console
swift test --enable-code-coverage

llvm-cov report .build/debug/butterflyPackageTests.xctest --instr-profile=.build/debug/codecov/default.profdata --ignore-filename-regex='(.build|Tests)[/\\].*' 
```

## Development

Generate keys for local testing

```
openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout key.pem -out cert.pem \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
```
