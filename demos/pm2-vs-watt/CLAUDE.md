# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands
- Run benchmark: `npm run bench`
- Start server: `node server.js`
- PM2 start: `npx pm2 start server.js`
- Watt start: `npx wattpm start server.js`

## Code Style
- **Format**: ES Modules (import/export)
- **Imports**: Use named imports/exports
- **HTTP**: Use Node.js core modules where possible
- **Error handling**: Handle errors appropriately with try/catch
- **Environment vars**: Use `process.env.PORT || defaultValue` pattern
- **Simplicity**: Keep code minimal for benchmarking purposes
- **Naming**: Use camelCase for variables/functions
- **Indentation**: 2 spaces