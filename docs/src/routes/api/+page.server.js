import { getApi } from '$lib/server/data.js';

export const load = () => ({ paths: getApi().map((p) => p.path) });
