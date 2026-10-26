-- Seed data for the local Supabase stack: three songs with generated cover
-- images and audio tracks that the storage surface serves.
--
-- The object paths match the files written by make-media.py.

insert into public.songs (title, author, image_path, song_path, created_at)
select seed.title, seed.author, seed.image_path, seed.song_path, seed.created_at
from (
    values
        ('Midnight Drive', 'Local Session', 'seed/cover-1.png', 'seed/track-1.wav', now() - interval '1 hour'),
        ('Neon Skyline', 'Local Session', 'seed/cover-2.png', 'seed/track-2.wav', now() - interval '2 hours'),
        ('Paper Planes', 'Local Session', 'seed/cover-3.png', 'seed/track-3.wav', now() - interval '3 hours')
) as seed(title, author, image_path, song_path, created_at)
where not exists (select 1 from public.songs);
