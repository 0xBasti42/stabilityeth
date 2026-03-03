<script lang="ts">
    interface Props {
        name: string;
        apy?: number;
        tvl?: number;
        onClaim?: () => void;
    }

    let { name, apy = 0, tvl = 0, onClaim }: Props = $props();

    function handleClaim() {
        if (onClaim) {
            onClaim();
        } else {
            console.log(`Claiming from ${name} vault`);
        }
    }
</script>

<div class="vault">
    <div class="vault-header">
        <h5>{name}</h5>
        <div class="network-icon"></div>
    </div>
    <p>TVL: ${tvl.toLocaleString()}</p>
    <p>PBR: {apy}%</p>
    <div class="button-container">
        <button class="claimButton" onclick={handleClaim}>Claim</button>
    </div>
</div>

<style>
    .vault {
        display: flex;
        flex-direction: column;
        align-items: flex-start;
        justify-content: center;
        background-color: var(--color-tertiary);
        border: 1px solid var(--color-secondary);
        border-radius: 1rem;
        padding: 1.5rem;
        min-height: 150px;
    }

    h5 {
        margin: 0 0 0.5rem 0;
        color: var(--color-secondary);
    }

    p {
        margin: 0.25rem 0;
        font-size: 0.875rem;
        color: var(--color-primary);
    }

    .vault-header {
        width: 100%;
        height: 40px;
        display: flex;
        flex-direction: row;
        align-items: center;
        justify-content: space-between;
    }

    .network-icon {
        width: 40px;
        height: 40px;
        background-color: var(--color-secondary);
        border-radius: 50%;
        margin-bottom: 5px;
    }

    .button-container {
        width: 100%;
        display: flex;
        flex-direction: row;
        align-items: center;
        justify-content: center;
    }

    .claimButton {
        margin-top: 2rem;
        margin-left: 0;
        width: 90%;
    }
</style>