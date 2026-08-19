# AGENTS.md

## Code style

- No comments unless asked.
- Check shared helpers/utils before writing a local one; don't create a helper for something that can stay inline.

## Commit style

- Use conventional commit.
- Never add description to commits unless asked.

## Naming things

- Avoid single-letter names — use names that communicate meaning.
- Avoid abbreviations — prefer clear, unambiguous words.
- Don’t encode types — users, not userList or usersArray.
- Include units when relevant — e.g. timeoutMs, distanceKm.
- Don’t encode implementation details — e.g. avoid IUser just because it’s an interface.
- Avoid Base / Abstract names — name things for what they represent, not their inheritance role.
- Avoid generic Utils / Helpers — group code by meaningful concepts.
- Put behavior with the concept it belongs to — make names and responsibilities align.
- If naming is difficult, question the design — the abstraction may be doing too much.

## Agent configs

- Never edit `CLAUDE.md`, `AGENTS.md`, or any other agent instruction file unless explicitly asked to.

