import { redirect } from '@sveltejs/kit';
import type { LayoutServerLoad } from './$types';

export const load: LayoutServerLoad = async ({ url, cookies }) => {
    if (url.pathname === '/') {
        throw redirect(307, '/exchange');
    }

    const isConnected = cookies.get('connected') === 'true';
    if (!isConnected && url.pathname.startsWith('/vaults')) {
        throw redirect(307, '/exchange');
    }

    return {
        connected: isConnected
    };
};