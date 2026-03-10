<script lang="ts">
    import Form from '$lib/components/Form.svelte';
    import Info from '$lib/components/Info.svelte';
</script>

<svelte:head>
    <title>StabilityEth | Registry</title>
    <meta name="description" content="Internet native currency for the world computer." />
    <meta name="robots" content="noindex,follow" />
    <!-- Open Graph tags -->
    <meta property="og:image" content="https://res.cloudinary.com/dtnxlt83m/image/upload/v1746833044/banner_rynyfg.png" />
    <meta property="og:title" content="StabilityEth | Registry" />
    <meta property="og:description" content="Internet native currency for the world computer." />
    <meta property="og:type" content="website" />
    <!-- Twitter Card tags -->
    <meta property="twitter:image" content="https://res.cloudinary.com/dtnxlt83m/image/upload/v1746833044/banner_rynyfg.png" />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content="StabilityEth | Registry" />
    <meta name="twitter:description" content="Internet native currency for the world computer." />
    <!-- Canonical URL to prevent duplicate content issues -->
    <link rel="canonical" href="https://stability-eth.io/registry/" />
</svelte:head>

<div class="exchange-outer">
    <div class="exchange-inner">
        <Form />
        <Info />
    </div>
</div>

<style>
    .exchange-outer {
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

    .exchange-inner {
        display: flex;
        flex-direction: row;
        align-items: center;
        justify-content: center;
        gap: 1rem;
        width: 100%;
        height: 100%;
        background: var(--color-background);
        border: 1px solid var(--color-secondary);
        border-radius: 1rem;
        padding: 1rem;
    }
</style>