<script>
  import { base } from '$app/paths';
  import data from '$lib/data.json';
</script>

<svelte:head><title>API - Mjolnir</title></svelte:head>

<h1>API reference</h1>
<p>
  Generated from <code>odin doc</code>.
</p>
<ul class="cols">
  {#each data.api as p (p.path)}
    <li><a href="{base}/api/{p.path}">{p.path}</a></li>
  {/each}
</ul>
