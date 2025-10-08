# Butterfly

## Testing

View test coverage

```console
swift test --enable-code-coverage

llvm-cov report .build/debug/butterflyPackageTests.xctest --instr-profile=.build/debug/codecov/default.profdata --ignore-filename-regex='(.build|Tests)[/\\].*' 
```
