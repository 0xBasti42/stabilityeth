import { writable } from 'svelte/store';

export const connected = writable(false);
export const address = writable('');