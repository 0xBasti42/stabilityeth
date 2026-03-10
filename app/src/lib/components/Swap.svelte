<script lang="ts">
    import { fade } from 'svelte/transition';
</script>

<div class="swap" in:fade={{ duration: 200 }}>

</div>

<style>
    .swap {
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        width: 33%;
        height: 100%;
        background-color: var(--color-tertiary);
        border: 1px solid var(--color-secondary);
        border-radius: 1rem;
        padding: 1rem;
    }
</style>