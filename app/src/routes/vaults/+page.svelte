<script lang="ts">
    import { fade } from 'svelte/transition';
    import Vault from '$lib/components/Vault.svelte';

    const vaults = [
        { id: 1, name: 'Ethereum', apy: 5.2, tvl: 1250000 },
        { id: 2, name: 'Base', apy: 8.1, tvl: 890000 },
        { id: 3, name: 'Arbitrum', apy: 12.5, tvl: 450000 },
        { id: 4, name: 'Optimism', apy: 15.3, tvl: 320000 },
        { id: 5, name: 'Monad', apy: 6.8, tvl: 780000 },
        { id: 6, name: 'MegaETH', apy: 9.4, tvl: 560000 },
        { id: 7, name: 'Solana', apy: 9.4, tvl: 560000 },
        { id: 8, name: 'Aptos', apy: 9.4, tvl: 560000 },
        { id: 9, name: 'Sui', apy: 9.4, tvl: 560000 },
    ];
</script>

<svelte:head>
    <title>StabilityEth | Vaults</title>
    <meta name="description" content="Internet native currency for the world computer." />
    <meta name="robots" content="noindex,follow" />
    <!-- Open Graph tags -->
    <meta property="og:image" content="https://res.cloudinary.com/dtnxlt83m/image/upload/v1746833044/banner_rynyfg.png" />
    <meta property="og:title" content="StabilityEth | Vaults" />
    <meta property="og:description" content="Internet native currency for the world computer." />
    <meta property="og:type" content="website" />
    <!-- Twitter Card tags -->
    <meta property="twitter:image" content="https://res.cloudinary.com/dtnxlt83m/image/upload/v1746833044/banner_rynyfg.png" />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content="StabilityEth | Vaults" />
    <meta name="twitter:description" content="Internet native currency for the world computer." />
    <!-- Canonical URL to prevent duplicate content issues -->
    <link rel="canonical" href="https://stability-eth.io/vaults/" />
</svelte:head>

<div class="vaults-outer">
    <div class="vaults-inner">
        <div class="vaults-grid" in:fade={{ duration: 200 }}>
            {#each vaults as vault (vault.id)}
                <Vault 
                    name={vault.name} 
                    apy={vault.apy} 
                    tvl={vault.tvl} 
                    onClaim={() => console.log(`Claimed from vault ${vault.id}: ${vault.name}`)}
                />
            {/each}
        </div>
    </div>
</div>

<style>
    .vaults-outer {
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        width: 100%;
        height: calc(100vh - 50px - 40px);
        background: var(--color-tertiary);
        border: 1px solid var(--color-secondary);
        border-radius: 1rem;
        padding: 1rem;
        cursor: default;
    }

    .vaults-inner {
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: flex-start;
        width: 100%;
        height: 100%;
        background: var(--color-background);
        border: 1px solid var(--color-secondary);
        border-radius: 1rem;
        padding: 2rem;
        overflow-y: auto;
    }

    .vaults-grid {
        display: grid;
        grid-template-columns: repeat(3, 1fr);
        gap: 1.5rem;
        width: 100%;
        max-width: 1000px;
    }

    @media (max-width: 768px) {
        .vaults-grid {
            grid-template-columns: repeat(2, 1fr);
        }
    }

    @media (max-width: 480px) {
        .vaults-grid {
            grid-template-columns: 1fr;
        }
    }
</style>