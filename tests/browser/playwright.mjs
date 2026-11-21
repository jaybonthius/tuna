import { createRequire } from "module";

// Resolved from this folder, so the copy its package.json pins is found
// first, then any other copy on NODE_PATH.
export default createRequire(import.meta.url)("playwright-core");
