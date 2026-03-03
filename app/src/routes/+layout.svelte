<script lang="ts">
	import '../app.css';
    import favicon from '$lib/assets/favicon.svg';
    import Logo from '$lib/components/Logo.svelte';
    import { page } from '$app/stores';
    import Connect from '$lib/components/Connect.svelte';
    import { connected } from '$lib/stores/header';

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
	<div class="header">
		<div class="logo">
			<Logo />
		</div>
		<div class="nav">
			<a href="/exchange" class:active={$page.url.pathname.startsWith('/exchange')}>Exchange</a>
			<a href="/registry" class:active={$page.url.pathname.startsWith('/registry')}>Registry</a>
		</div>
		<div class="connect">
			{#if $connected}<a href="/vaults" class:active={$page.url.pathname.startsWith('/vaults')}>Vaults</a>{/if}
			<Connect />
		</div>
	</div>

	{@render children()}

	<div class="footer">
		<div class="footer-links">
			<a id="x" href="https://x.com/StabilityETH" target="_blank" rel="noopener noreferrer" aria-label="X">
				<i class="fa-brands fa-x-twitter icon" style="font-size: 16px;"></i>
			</a>
			<a id="github" href="https://github.com/isla-labs/stability-eth" target="_blank" rel="noopener noreferrer" aria-label="GitHub">
				<i class="fa-brands fa-github icon" style="font-size: 16px;"></i>
			</a>
		</div>
	</div>

	<button class="ai-chat-button" aria-label="Open AI Chat">
		<i class="fa-solid fa-robot icon" style="margin-left: 2px; font-size: 18px;"></i>
	</button>
</div>

<style>
	.layout {
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
	}
	
	.header {
		display: flex;
		flex-direction: row;
		align-items: center;
		justify-content: space-between;
		width: 100%;
		padding: 1rem;
		height: 50px;
	}

	.footer {
		display: flex;
		flex-direction: row;
		align-items: center;
		justify-content: center;
		width: 100%;
		padding: 1rem;
		height: 40px;
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

	.nav {
		display: flex;
		flex-direction: row;
		align-items: center;
		justify-content: center;
		gap: 2rem;
	}

	.connect {
		width: 250px;
		display: flex;
		flex-direction: row;
		align-items: center;
		justify-content: flex-end;
		gap: 1rem;
	}

	.ai-chat-button {
		position: fixed;
		bottom: 1.5rem;
		right: 1.5rem;
		width: 50px;
		height: 50px;
		border-radius: 50%;
		border: none;
		background: #fff;
		color: #2b2b2b;
		cursor: pointer;
		display: flex;
		align-items: center;
		justify-content: center;
		transition: transform 0.15s ease-out, box-shadow 0.2s ease-out, background 0.15s ease-out;
		z-index: 1000;
	}

	.ai-chat-button:hover {
		transform: scale(1.04) translateY(-2px);
	}

	.ai-chat-button:active {
		opacity: 1;
		transform: scale(1.02) translateY(-2px);
		background: #d6d6d6;
	}

	.ai-chat-button i {
		transition: transform 0.15s ease-out;
	}	

	.ai-chat-button:hover i {
		transform: scale(0.96) translateY(-2px);
		transition: transform 0.05s ease-out;
	}	

	.ai-chat-button:active i {
		transform: scale(1.04) translateY(-2px);
	}
</style>