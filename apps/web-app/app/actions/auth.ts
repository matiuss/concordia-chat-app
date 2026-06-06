'use server';

// INTERNAL_API_URL is only available server-side; NEXT_PUBLIC_API_URL is the
// fallback so the module compiles in environments without Docker env vars.
const GATEWAY = process.env.INTERNAL_API_URL ?? process.env.NEXT_PUBLIC_API_URL ?? 'http://gateway:8080';

export type AuthState =
  | { error?: string; tokens?: { access_token: string; refresh_token: string; expires_in: number } }
  | undefined;

export async function loginAction(
  _state: AuthState,
  formData: FormData,
): Promise<AuthState> {
  const email = (formData.get('email') as string | null)?.trim() ?? '';
  const password = (formData.get('password') as string | null) ?? '';

  if (!email || !password) {
    return { error: 'Email and password are required.' };
  }

  let res: Response;
  try {
    res = await fetch(`${GATEWAY}/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password }),
    });
  } catch {
    return { error: 'Could not reach the server. Please try again.' };
  }

  if (!res.ok) {
    const body = await res.json().catch(() => ({})) as Record<string, string>;
    return { error: body.error ?? 'Invalid email or password.' };
  }

  const tokens = await res.json() as {
    access_token: string;
    refresh_token: string;
    expires_in: number;
  };

  return { tokens };
}

export async function registerAction(
  _state: AuthState,
  formData: FormData,
): Promise<AuthState> {
  const username = (formData.get('username') as string | null)?.trim() ?? '';
  const email = (formData.get('email') as string | null)?.trim() ?? '';
  const password = (formData.get('password') as string | null) ?? '';

  if (!username || !email || !password) {
    return { error: 'All fields are required.' };
  }

  let res: Response;
  try {
    res = await fetch(`${GATEWAY}/auth/register`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username, email, password }),
    });
  } catch {
    return { error: 'Could not reach the server. Please try again.' };
  }

  if (!res.ok) {
    const body = await res.json().catch(() => ({})) as Record<string, string>;
    return { error: body.error ?? 'Registration failed. Please try again.' };
  }

  return undefined;
}

// accessToken is passed in by the caller because Server Actions cannot access
// localStorage. The caller is responsible for clearing tokens client-side.
export async function logoutAction(accessToken: string): Promise<void> {
  if (accessToken) {
    await fetch(`${GATEWAY}/auth/logout`, {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${accessToken}` },
    }).catch(() => {});
  }
}
