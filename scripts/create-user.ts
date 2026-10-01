// Bootstrap the first member (everyone after that is invited with add_friend).
// Usage: DATABASE_URL=… npm run create-user -- <handle> "<Display Name>" <public origin>
import { setupCommands } from "../api/index.js";
import { createUser, HANDLE, sql } from "../src/board.js";

const [handle, name, origin] = process.argv.slice(2);
if (!handle || !name || !origin || !HANDLE.test(handle)) {
  console.error('Usage: npm run create-user -- <handle> "<Display Name>" https://<host>');
  process.exit(1);
}
const user = await createUser(sql, handle, name);
console.log(user ? setupCommands(origin, user.key) : `'${handle}' is taken.`);
await sql.end();
