<script lang="ts">
    import { connected } from '$lib/stores/header';
    import { invalidateAll } from '$app/navigation';

    async function toggleConnection() {
        const newState = !$connected;
        
        // Update server-side cookie
        await fetch('/api/auth', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ connected: newState })
        });

        // Update client-side store
        connected.set(newState);

        // Invalidate all load functions to re-run server checks
        await invalidateAll();
    }
</script>

<button 
    class="connectButton" 
    onclick={toggleConnection}
    style="font-size: 10px; border: 1px solid #999999;"
>
    {$connected ? '♢ 1.42' : 'Connect'}
</button>

<style>

</style>