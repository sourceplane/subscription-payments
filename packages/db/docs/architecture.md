# db — architecture

A workspace package at `packages/db`, consumed at build time by the components
that depend on it. It holds no credentials and opens no connections of its own.

## Exports

- `.`
- `./manifest`
- `./runner`
- `./types`
