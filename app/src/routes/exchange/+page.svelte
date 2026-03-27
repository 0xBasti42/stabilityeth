<script lang="ts">
    import Swap from '$lib/components/Swap.svelte';
    import banner from '$lib/assets/banner.png';
</script>

<svelte:head>
    <title>sETH Exchange</title>
    <meta name="description" content="Turning TVL into an additional source of revenue for verified dApps." />
    <meta name="robots" content="noindex,follow" />
    <!-- Open Graph tags -->
    <meta property="og:image" content="https://res.cloudinary.com/dtnxlt83m/image/upload/v1746833044/banner_rynyfg.png" />
    <meta property="og:title" content="sETH Exchange" />
    <meta property="og:description" content="Turning TVL into an additional source of revenue for verified dApps." />
    <meta property="og:type" content="website" />
    <!-- Twitter Card tags -->
    <meta property="twitter:image" content="https://res.cloudinary.com/dtnxlt83m/image/upload/v1746833044/banner_rynyfg.png" />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content="sETH Exchange" />
    <meta name="twitter:description" content="Turning TVL into an additional source of revenue for verified dApps." />
    <!-- Canonical URL to prevent duplicate content issues -->
    <link rel="canonical" href="https://stability-eth.io/exchange/" />
</svelte:head>

<div class="exchange-outer">
    <div class="exchange-inner">
        <Swap />
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
        border-radius: 1rem;
        cursor: default;
    }

    .exchange-inner {
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        width: 100%;
        height: 100%;
        border-radius: 1rem;
    }
</style>