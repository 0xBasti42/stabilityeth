import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = async ({ cookies, request }) => {
    const { connected } = await request.json();
    
    if (connected) {
        cookies.set('connected', 'true', {
            path: '/',
            httpOnly: true,
            secure: process.env.NODE_ENV === 'production',
            sameSite: 'strict',
            maxAge: 60 * 60 * 24 * 7 // 1 week
        });
    } else {
        cookies.delete('connected', { path: '/' });
    }

    return json({ success: true });
};