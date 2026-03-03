<script lang="ts">

</script>

<div class="info">
    <div class="info-header">
        <h5>App Registry</h5>
        <p class="secondaryFont">Registered applications earn automatic Performance Based Returns (PBR) via the global fee treasury, which is distributed proportionally according to TVL.</p>
        <p class="secondaryFont">This turns TVL into <a href="/faq" class="primaryFont moreInfo">additional revenue for verified apps</a> on the EVM and SVM.</p>
    </div>
    <div class="info-content">
        <div class="info-content-item">
            <p class="secondaryFont">Deployer</p>
        </div>
        <div class="info-content-item">
            <p class="secondaryFont">Beneficiary</p>
        </div>
        <div class="info-content-item">
            <p class="secondaryFont">Chain ID</p>
        </div>
        <div class="info-content-item">
            <p class="secondaryFont">List of contract addresses separated by a comma ( , , , )</p>
        </div>
        <div class="info-content-item">
            <p class="secondaryFont">List of ERC/SPL token addresses to consider for TVL ( , , , )</p>
        </div>
        <div class="info-content-item">
            <button class="secondaryFont verifyButton">Verify</button>
            <div class="progressBar">
                <div class="progressBar-fill no1"></div>
                <div class="progressBar-fill no2"></div>
            </div>
        </div>
        <div class="info-content-item">
            <button class="secondaryFont verifyButton" disabled={true}>Submit Tx</button>
        </div>
    </div>
</div>

<style>
    .info {
        display: flex;
        flex-direction: column;
        align-items: flex-start;
        justify-content: flex-start;
        width: 66%;
        height: 100%;
        background-color: var(--color-background);
        border-radius: 2rem;
        padding: 1rem;
        padding-bottom: 0;
        gap: 1rem;
    }

    .info-header {
        display: flex;
        flex-direction: column;
        align-items: flex-start;
        justify-content: flex-start;
        gap: 0.5rem;
    }

    .info-header p {
        line-height: 1.6;
    }

    .moreInfo {
        cursor: pointer;
        margin-left: 0;
        text-decoration-color: var(--color-primary);
        text-decoration-thickness: 1px;
        text-underline-offset: 2px;
        transition: all 0.2s ease-out;
        &:hover {
            text-decoration: underline;
        }
        &:active {
            opacity: 0.6;
        }
    }

    .info-content {
        display: flex;
        flex-direction: column;
        align-items: flex-start;
        justify-content: flex-start;
        gap: 0.5rem;
        flex: 1;
        overflow-y: auto;
        width: 100%;
        padding-right: 5px;
    }

    .info-content-item {
        background-color: var(--color-tertiary);
        width: 100%;
        border-radius: 0.5rem;
        padding: 1rem;
        display: flex;
        flex-direction: row;
        align-items: flex-start;
        justify-content: flex-start;
        gap: 0.5rem;
    }

    .info-content-item:last-child {
        background-color: var(--color-tertiary);
    }

    .info-content::-webkit-scrollbar {
        width: 3px;
    }

    .info-content::-webkit-scrollbar-track {
        background: var(--color-tertiary);
        /* or: background: var(--color-tertiary); */
    }

    .info-content::-webkit-scrollbar-thumb {
        background: rgba(255, 255, 255, 0.2);
        border-radius: 4px;
    }

    .info-content::-webkit-scrollbar-thumb:hover {
        background: rgba(255, 255, 255, 0.3);
    }

    .verifyButton {
        width: auto;
        margin-left: 0;
    }

    .verifyButton:disabled {
        opacity: 0.5;
        cursor: default;
        /* any other styles for disabled state */
    }

    .verifyButton:disabled:hover {
        /* prevent hover effects on disabled button */
        background-color: inherit;
        color: var(--color-secondary);
        transform: none;
    }

    .progressBar {
        flex: 1;
        height: 100%;
        background-color: #303030;
        display: flex;
        flex-direction: row;
        align-items: center;
    }

    .progressBar-fill {
        height: 33%;
    }

    .no1 {
        width: 10%;
        background-color: var(--color-primary);
    }

    .no2 {
        width: 90%;
        background-color: var(--color-secondary);
    }
</style>