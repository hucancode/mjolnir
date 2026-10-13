<script>
  import { base } from '$app/paths';
  import data from '$lib/data.json';
</script>

<svelte:head><title>Examples - Mjolnir</title></svelte:head>

<h1>Examples</h1>
<div class="grid">
  {#each data.examples as e (e.name)}
    <div class="card" id={e.name}>
    <figure>
      {#if e.video}
        <video src="{base}/videos/{e.name}.mp4" autoplay muted loop playsinline preload="metadata"></video>
      {:else}
        <div class="missing">video not yet recorded</div>
      {/if}
      <figcaption>
        <code>{e.name}</code>
        <small>{e.desc}</small>
      </figcaption>
    </figure>
      <details>
        <summary>Show code</summary>
        <pre><code>{e.source}</code></pre>
      </details>
    </div>
  {/each}
</div>
