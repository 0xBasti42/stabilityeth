<script lang="ts">

</script>

<svelte:head>
    <title>StabilityEth | FAQ</title>
    <meta name="description" content="Internet native currency for the world computer." />
    <meta name="robots" content="noindex,follow" />
    <!-- Open Graph tags -->
    <meta property="og:image" content="https://res.cloudinary.com/dtnxlt83m/image/upload/v1746833044/banner_rynyfg.png" />
    <meta property="og:title" content="StabilityEth | FAQ" />
    <meta property="og:description" content="Internet native currency for the world computer." />
    <meta property="og:type" content="website" />
    <!-- Twitter Card tags -->
    <meta property="twitter:image" content="https://res.cloudinary.com/dtnxlt83m/image/upload/v1746833044/banner_rynyfg.png" />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content="StabilityEth | FAQ" />
    <meta name="twitter:description" content="Internet native currency for the world computer." />
    <!-- Canonical URL to prevent duplicate content issues -->
    <link rel="canonical" href="https://stability-eth.io/faq/" />
</svelte:head>

<div class="exchange-outer">
    <div class="exchange-inner">
        <div class="faq-header">
            <div class="faq-header-back">
                <i class="fa-solid fa-arrow-left" style="font-size: 10px; color: var(--color-secondary); margin-top: 2px;"></i>
                <a href="/registry" class="secondaryFont">Back to Registry</a>
            </div>
        </div>
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
        flex-direction: column;
        align-items: flex-start;
        justify-content: flex-start;
        width: 100%;
        height: 100%;
        background: var(--color-background);
        border: 1px solid var(--color-secondary);
        border-radius: 1rem;
        padding: 1rem;
    }

    .faq-header {
        display: flex;
        flex-direction: row;
        align-items: center;
        justify-content: space-between;
    }

    .faq-header-back {
        display: flex;
        flex-direction: row;
        align-items: center;
        justify-content: flex-start;
        gap: 0.5rem;
        cursor: pointer;
        transition: all 0.2s ease-out;
    }

    .faq-header-back i {
        transition: all 0.1s ease-out;
    }

    .faq-header-back a {
        transition: all 0.2s ease-out;
        margin-left: 0;
    }

    .faq-header-back:hover a {
        color: var(--color-primary);
    }

    .faq-header-back:active i {
        transform: translateX(-5px);
    }

    .faq-header-back:active {
        opacity: 0.6;
    }
</style>