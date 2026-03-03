# Struktura

Struktura is a lightweight **Services / Controllers** framework for Roblox, built to keep your game architecture clean and your networking surface small.

It’s designed for:
- **Server-side Services** that own game logic + state
- **Client-side Controllers** that drive UI / input / presentation
- A simple, consistent way to expose **server APIs** and **server → client signals** without writing boilerplate remotes


It's recommended to use:
- **Replicator** can be used alongside this for state-managed logic
- **Trove** is my recommendation as a cleanup library
