/*
 * PixelQuest global monochrome pass.
 * Converts RGB to perceptual luminance while preserving alpha.
 */
#if defined(VERTEX)
uniform mat4 MVPMatrix;
attribute vec4 VertexCoord;
attribute vec4 TexCoord;
attribute vec4 Color;
varying vec2 tex_coord;

void main()
{
   gl_Position = MVPMatrix * VertexCoord;
   tex_coord = TexCoord.xy;
}
#elif defined(FRAGMENT)
#ifdef GL_ES
precision mediump float;
#endif
uniform sampler2D Texture;
varying vec2 tex_coord;

void main()
{
   vec4 color = texture2D(Texture, tex_coord);
   float luminance = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
   gl_FragColor = vec4(vec3(luminance), color.a);
}
#endif
