<script lang="ts">
    import { fade } from 'svelte/transition';
</script>

<div class="swap" in:fade={{ duration: 300 }}>

</div>

<style>
    .swap {
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        width: 33%;
        height: 100%;
        background-color: #2b2b2b;
        border: 1px solid var(--color-secondary);
        border-radius: 1rem;
        padding: 1rem;
    }
</style>