# skir-client-async

Async MoonBit runtime for SkirRPC Service and ServiceClient.

## Install

```bash
moon add gepheum/skir-client-async
```

## Development

```bash
moon fmt --check
moon check
moon test
```

## E2E demo

```bash
cd e2e-test
./generate.sh
moon run --target native src/start_service.mbt
# in another terminal
moon test --target native ./src/call_service.mbt
```

## License

MIT
