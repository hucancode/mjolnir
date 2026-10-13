<script>
  import { base } from '$app/paths';
  let { data } = $props();
  let pkg = $derived(data.pkg);
</script>

<svelte:head><title>{pkg.path} - Mjolnir</title></svelte:head>

<p><a href="{base}/api">API</a> /</p>
<h1>{pkg.path}</h1>
{#if pkg.doc}<p style="white-space: pre-line">{pkg.doc}</p>{/if}
{#each pkg.sections as [name, syms] (name)}
  <h2>{name}</h2>
  {#each syms as s (s.sig)}
    <div class="sym">
      <code>{s.sig}</code>
      {#if s.doc}<p>{s.doc}</p>{/if}
    </div>
  {/each}
{/each}
