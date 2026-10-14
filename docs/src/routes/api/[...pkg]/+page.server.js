import { getApi } from '$lib/server/data.js';
import { error } from '@sveltejs/kit';

export const entries = () => getApi().map((p) => ({ pkg: p.path }));

export function load({ params }) {
  const pkg = getApi().find((p) => p.path === params.pkg);
  if (!pkg) error(404, 'unknown package');
  return { pkg };
}
