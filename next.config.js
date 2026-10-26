/** @type {import('next').NextConfig} */
const nextConfig = {
    images: {
        domains: ['ccxvulyfmdiwkcyubntm.supabase.co'],
        // The local Supabase-compatible stack serves storage objects from
        // 127.0.0.1:54321; the hosted project above stays allowed for
        // deployments that still point at it.
        remotePatterns: [
            {
                protocol: 'http',
                hostname: '127.0.0.1',
                port: '54321',
            },
        ],
    },
};

module.exports = nextConfig;
