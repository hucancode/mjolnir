import data from '$lib/data.json';
import { error } from '@sveltejs/kit';

export const entries = () => data.api.map((p) => ({ pkg: p.path }));

export function load({ params }) {
  const pkg = data.api.find((p) => p.path === params.pkg);
  if (!pkg) error(404, 'unknown package');
  return { pkg };
}
