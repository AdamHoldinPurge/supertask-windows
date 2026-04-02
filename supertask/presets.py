"""Creative direction presets for SuperTask™ variants."""

PRESET_NAMES = [
    'Faithful', 'Hyper-Creative', 'Ultra-Modern Minimalist',
    'Bold & Maximalist', 'Dark & Premium', 'Playful & Energetic',
    'Retro & Nostalgic', 'Organic & Natural', 'Corporate & Professional',
    'Avant-Garde & Experimental', 'Brutalist & Raw', 'Warm & Inviting',
]

PRESET_DESCRIPTIONS = {
    'Faithful':
        'Execute exactly as described \u2014 no creative liberties.',
    'Hyper-Creative':
        'Break conventions, unexpected colour combos, asymmetric layouts, '
        'surprise the viewer. Mix media, experiment with typography, '
        'use whitespace dramatically. Think art installation, not template.',
    'Ultra-Modern Minimalist':
        'Swiss/Scandinavian design. Max 2 colours + neutrals. '
        'Generous whitespace, clean grid, sharp sans-serif type. '
        'Every element earns its place. Remove until it breaks, then add one thing back.',
    'Bold & Maximalist':
        'More is more. Dense layouts, layered textures, rich colour palettes, '
        'bold typography at scale. Fill the space with energy. '
        'Overlap elements, use gradients, shadows, and depth.',
    'Dark & Premium':
        'Dark backgrounds, muted golds/silvers, luxury feel. '
        'Subtle gradients, glass morphism, premium card designs. '
        'Elegant serif or thin sans-serif type. Feels expensive.',
    'Playful & Energetic':
        'Bright saturated colours, rounded corners everywhere, '
        'bouncy animations, friendly illustrations or icons. '
        'Feels like a startup that actually ships. Comic Sans banned, but that vibe.',
    'Retro & Nostalgic':
        'Warm earth tones, film grain textures, serif fonts, '
        'vintage colour palettes (burnt orange, olive, cream). '
        'Feels like a well-designed magazine from 1973. Tactile and warm.',
    'Organic & Natural':
        'Earth tones, soft curves, nature-inspired shapes and textures. '
        'Hand-drawn elements, watercolour washes, botanical accents. '
        'Feels calm, grounded, and human-made.',
    'Corporate & Professional':
        'Clean grid-based layouts, blue/grey palette, trust signals. '
        'Professional photography, structured navigation, clear hierarchy. '
        'Enterprise-grade but not boring. Think Stripe, not Oracle.',
    'Avant-Garde & Experimental':
        'Push boundaries. Unconventional layouts, artistic typography, '
        'unexpected interactions. Break the grid intentionally. '
        'Feels like a design award submission. Form follows concept.',
    'Brutalist & Raw':
        'Raw HTML energy. Monospace fonts, exposed structure, '
        'system colours, dense text, no unnecessary decoration. '
        'Feels intentionally rough. Performance is aesthetic.',
    'Warm & Inviting':
        'Soft shadows, rounded corners, warm colour palette '
        '(peach, sage, cream, terracotta). Comfortable spacing, '
        'friendly copy. Feels like a cozy cafe with good WiFi.',
}


def get_preset_description(name):
    """Get the full description for a preset name. Returns empty string if not found."""
    return PRESET_DESCRIPTIONS.get(name, '')
