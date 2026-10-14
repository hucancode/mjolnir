import { getExamples } from '$lib/server/data.js';

export const load = () => ({ examples: getExamples() });
