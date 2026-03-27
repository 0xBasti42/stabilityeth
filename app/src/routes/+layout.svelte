<script lang="ts">
	import '../app.css';
    import favicon from '$lib/assets/favicon.svg';
    import Logo from '$lib/components/Logo.svelte';
    import { page } from '$app/stores';
    import Connect from '$lib/components/Connect.svelte';
    import { connected } from '$lib/stores/header';
	import { chatPanelVisible } from '$lib/stores/chatPanel';

	let { children, data } = $props();

	// Sync server state to client store on load
    $effect(() => {
        connected.set(data.connected);
    });
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
</svelte:head>

<div class="layout">
	<header class="header">
		<div class="logo">
			<Logo />
		</div>
		<div class="header-spacer" aria-hidden="true"></div>
		<div class="connect">
			<Connect />
		</div>
	</header>

	<div class="shell">
		<aside class="sidebar" aria-label="Main navigation">
			<nav class="sidebar-nav">
				<p class="secondaryFont">Main</p>
				<a
					href="/exchange"
					class="sidebar-main-link"
					class:active={$page.url.pathname.startsWith('/exchange')}
				>
					<span class="sidebar-main-label">Exchange</span>
					<i class="fa-solid fa-chevron-right sidebar-main-chevron" aria-hidden="true"></i>
				</a>
				<a
					href="/registry"
					class="sidebar-main-link"
					class:active={$page.url.pathname.startsWith('/registry')}
				>
					<span class="sidebar-main-label">Registry</span>
					<i class="fa-solid fa-chevron-right sidebar-main-chevron" aria-hidden="true"></i>
				</a>
				{#if $connected}
					<a
						href="/vaults"
						class="sidebar-main-link"
						class:active={$page.url.pathname.startsWith('/vaults')}
					>
						<span class="sidebar-main-label">Vaults</span>
						<i class="fa-solid fa-chevron-right sidebar-main-chevron" aria-hidden="true"></i>
					</a>
				{/if}
				<p class="secondaryFont title-not-top">Ext.</p>
				<a href="https://docs.stabilityeth.io/" target="_blank" rel="noopener noreferrer" aria-label="Developers">Developers</a>
				<a href="https://etherscan.io/idm?addresses=0x5642e5ff9e48e0659060aee428754a6dd10f5b08&type=1" target="_blank" rel="noopener noreferrer" aria-label="EF Mandate">EF Mandate</a>
			</nav>
		</aside>
		<main class="main">
			{@render children()}
		</main>
		{#if $chatPanelVisible}
			<aside class="chat-panel" aria-label="AI assistant chat">
				<div class="chat-panel-header">
					<i class="fa-solid fa-robot chat-panel-icon" aria-hidden="true"></i>
					<span class="chat-panel-title">Mr.Etherium</span>
				</div>
				<div class="chat-panel-messages">
					<p class="secondaryFont chat-panel-placeholder">
						Ask questions about StabilityETH, swaps, or the registry.
					</p>
				</div>
				<div class="chat-panel-input-row">
					<label class="visually-hidden" for="layout-ai-chat-input">Message</label>
					<input
						id="layout-ai-chat-input"
						class="chat-panel-input"
						type="text"
						placeholder="Type a message…"
						autocomplete="off"
					/>
				</div>
			</aside>
		{/if}
	</div>

	<footer class="footer">
		<div class="footer-links">
			<a id="x" href="https://x.com/StabilityETH" target="_blank" rel="noopener noreferrer" aria-label="X">
				<i class="fa-brands fa-x-twitter icon" style="font-size: 16px;"></i>
			</a>
			<a id="github" href="https://github.com/isla-labs/stability-eth" target="_blank" rel="noopener noreferrer" aria-label="GitHub">
				<i class="fa-brands fa-github icon" style="font-size: 16px;"></i>
			</a>
		</div>
	</footer>
</div>

<style>
	.layout {
		display: flex;
		flex-direction: column;
		height: 100vh;
		max-height: 100vh;
		height: 100dvh;
		max-height: 100dvh;
		width: 100%;
		align-items: stretch;
		overflow: hidden;
	}

	.header {
		display: flex;
		flex-direction: row;
		align-items: center;
		justify-content: space-between;
		width: 100%;
		flex-shrink: 0;
		padding: 1rem;
		min-height: 50px;
		border-bottom: 1px solid var(--color-border);
		background-color: var(--color-tertiary);
	}

	.header-spacer {
		flex: 1;
		min-width: 0;
	}

	.shell {
		display: flex;
		flex-direction: row;
		flex: 1 1 0;
		width: 100%;
		min-height: 0;
		align-items: stretch;
		overflow: hidden;
	}

	.sidebar {
		flex-shrink: 0;
		width: 220px;
		padding: 1.5rem 1rem;
		border-right: 1px solid var(--color-border);
		background: var(--color-tertiary);
		overflow-y: auto;
		min-height: 0;
	}

	.sidebar-nav {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 1rem;
	}

	.title-not-top {
		margin-top: 0.5rem;
	}

	.sidebar-nav a:not(.sidebar-main-link) {
		margin-left: 0.5rem;
		letter-spacing: 0.18em;
	}

	.sidebar-main-link {
		display: flex;
		flex-direction: row;
		align-items: center;
		justify-content: space-between;
		align-self: stretch;
		gap: 0.5rem;
		margin-left: 0.5rem;
		padding-right: 0.15rem;
		box-sizing: border-box;
		letter-spacing: 0.18em;
	}

	.sidebar-main-label {
		min-width: 0;
	}

	.sidebar-main-chevron {
		font-size: 0.55rem;
		color: #999999;
		opacity: 0;
		transform: translateX(-0.35rem);
		transition:
			opacity 0.15s ease-out,
			transform 0.15s ease-out,
			color 0.15s ease-out;
		flex-shrink: 0;
	}

	.sidebar-main-link:hover .sidebar-main-chevron,
	.sidebar-main-link.active .sidebar-main-chevron,
	.sidebar-main-link:focus-visible .sidebar-main-chevron {
		opacity: 1;
		transform: translateX(0);
		color: #999999;
	}

	.main {
		flex: 1 1 0;
		min-width: 0;
		min-height: 0;
		overflow-x: hidden;
		overflow-y: auto;
		display: flex;
		flex-direction: column;
		align-items: center;
	}

	.footer {
		display: flex;
		flex-direction: row;
		align-items: center;
		justify-content: center;
		width: 100%;
		flex-shrink: 0;
		padding: 1rem;
		min-height: 40px;
		border-top: 1px solid var(--color-border);
		background-color: var(--color-tertiary);
	}

	.footer-links {
		display: flex;
		flex-direction: row;
		align-items: center;
		justify-content: center;
		gap: 1rem;
	}

	.logo {
		width: 250px;
		display: flex;
		flex-direction: row;
		align-items: center;
		justify-content: flex-start;
	}

	.connect {
		width: 250px;
		display: flex;
		flex-direction: row;
		align-items: center;
		justify-content: flex-end;
		gap: 1rem;
	}

	.chat-panel {
		flex-shrink: 0;
		width: 22rem;
		align-self: center;
		height: min(70vh, 400px);
		height: min(70dvh, 400px);
		max-height: 100%;
		margin: 0;
		display: flex;
		flex-direction: column;
		min-height: 0;
		border: 1px solid var(--color-border);
		border-right: none;
		border-radius: 5px 0 0 5px;
		background-color: var(--color-tertiary);
		overflow: hidden;
		z-index: 2;
	}

	.chat-panel-header {
		flex-shrink: 0;
		display: flex;
		flex-direction: row;
		align-items: center;
		gap: 0.65rem;
		padding: 1rem;
		border-bottom: 1px solid var(--color-border);
	}

	.chat-panel-icon {
		font-size: 1rem;
		color: var(--color-primary);
		opacity: 0.9;
	}

	.chat-panel-title {
		font-family: 'Inter', sans-serif;
		font-weight: 200;
		letter-spacing: 0.22em;
		font-size: 0.75rem;
		color: var(--color-primary);
		text-transform: uppercase;
	}

	.chat-panel-messages {
		flex: 1 1 0;
		min-height: 0;
		overflow-y: auto;
		padding: 1rem;
	}

	.chat-panel-placeholder {
		letter-spacing: 0.12em;
		line-height: 1.6;
	}

	.chat-panel-input-row {
		flex-shrink: 0;
		padding: 0.75rem 1rem 1rem;
		border-top: 1px solid var(--color-border);
	}

	.chat-panel-input {
		width: 100%;
		box-sizing: border-box;
		font-family: 'Inter', sans-serif;
		font-weight: 200;
		letter-spacing: 0.14em;
		font-size: 0.75rem;
		color: var(--color-primary);
		background: var(--color-tertiary);
		border: 1px solid var(--color-border);
		border-radius: var(--border-radius);
		padding: 0.5rem 0.65rem;
		outline: none;
		transition: border-color 0.15s ease-out;
	}

	.chat-panel-input::placeholder {
		color: var(--color-secondary);
	}

	.chat-panel-input:focus {
		border-color: var(--color-primary);
	}

	.visually-hidden {
		position: absolute;
		width: 1px;
		height: 1px;
		padding: 0;
		margin: -1px;
		overflow: hidden;
		clip: rect(0, 0, 0, 0);
		white-space: nowrap;
		border: 0;
	}
</style>
