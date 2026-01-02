
import { createClient } from '@supabase/supabase-js';

/**
 * SUPABASE INITIALIZATION
 * Project: FinTab (ckwezgmunqqjjzccmuim)
 */
const supabaseUrl: string = 'https://ckwezgmunqqjjzccmuim.supabase.co';
const supabaseAnonKey: string = 'sb_publishable_lfCwM8KxDknwHharVAjkmw_RRVPwy0l';

export const supabase = createClient(supabaseUrl, supabaseAnonKey);

export const isSupabaseConfigured = 
    supabaseUrl !== 'https://YOUR_PROJECT_ID.supabase.co' && 
    supabaseAnonKey !== 'YOUR_SUPABASE_ANON_KEY';
