<script>
  import { base } from '$app/paths';
  let { data } = $props();
</script>

<svelte:head><title>API - Mjolnir</title></svelte:head>

<h1>API reference</h1>
<p>
  Generated from <code>odin doc</code>.
</p>
<ul class="cols">
  {#each data.paths as p (p)}
    <li><a href="{base}/api/{p}">{p}</a></li>
  {/each}
</ul>
