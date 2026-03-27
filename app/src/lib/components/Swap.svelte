<script lang="ts">
    import { fade } from 'svelte/transition';
    import { chatPanelVisible } from '$lib/stores/chatPanel';
</script>

<div class="swap" in:fade={{ duration: 200 }} style="margin-right: {$chatPanelVisible ? 'calc(220px - 22rem)' : '220px'};">
    <div class="swap-header">

    </div>
    <div class="swap-body">
        <div class="swap-input">
        </div>
        <div class="swap-line"></div>
        <div class="swap-output">
        </div>
    </div>
    <div class="swap-footer">

    </div>
</div>

<style>
    .swap {
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        width: min(28rem, 80%);
        height: min(600px, 85%);
        border: 1px solid var(--color-border);
        border-radius: var(--border-radius);
        background-color: var(--color-tertiary);
        margin-right: calc(220px - 22rem);
    }

    .swap-header {
        width: 100%;
        height: 60px;
        border-bottom: 1px solid var(--color-border);
        border-radius: var(--border-radius) var(--border-radius) 0 0;
    }

    .swap-body {
        width: 100%;
        height: 100%;
        border-bottom: 1px solid var(--color-border);
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
    }

    .swap-input {
        flex: 1;
        width: 100%;
        border-bottom: 1px solid var(--color-border);
    }

    .swap-output {
        flex: 1;
        width: 100%;
    }

    .swap-footer {
        width: 100%;
        height: 100px;
        border-radius: 0 0 var(--border-radius) var(--border-radius);
    }
</style>