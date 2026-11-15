# Prueba web de NasaSp

Sitio publicado:
https://nasasp-mission-trainer-rejax.profoundhedge8.chatgpt.site

El acceso es privado para la cuenta propietaria. Inicia sesión con ChatGPT
si aparece la pantalla de acceso. No necesitas Godot ni Blender para jugar.

1. Abre el sitio en computadora con teclado y ratón.
2. Pulsa **Preparar misión** y espera a que cargue la cabina.
3. Pulsa **Entrar a la cabina**. En ese momento comienza el reloj de 3 minutos.
4. Recoge las tres herramientas de la mesa con **E**.
5. Gira hacia los paneles señalados y repara cada uno manteniendo clic:
   fuga con soplete, reactor con llave inglesa y comunicaciones con rachet.
6. Tras la alerta solar, sal por el oeste hacia la sala de oxígeno y
   permanece dentro del refugio hasta que termine el evento.

**Controles:** WASD mueve, ratón mira, 1–6 o rueda equipa, E recoge,
clic mantenido repara, Q suelta, C agacha, Espacio salta y Esc pausa.
Si el navegador no captura el ratón, usa las flechas para mirar o arrastra
con el botón derecho. Al terminar, pulsa R o el botón Reiniciar misión.

La partida termina por victoria, exposición al estallido, tiempo agotado
u oxígeno agotado. El ejemplo solar está identificado como simulación:
esta misión autónoma no consulta datos NASA en vivo.

La exportación actualizada está en `WEB/`. Debe servirse por HTTP; abrir
`index.html` con doble clic no permite cargar correctamente los recursos.
El runtime está dividido entre `index.wasm.part0` e `index.wasm.part1`.

Los modos `?mcp=1`, `?sala=CODIGO` y escritorio `-- --mcp` conservan el
director remoto. La misión autónoma no arranca en esas sesiones.

Validación realizada en el runtime Web Godot 4.7.2: 33 comprobaciones sin
fallos, incluyendo herramientas, tareas, pausa, ruta al refugio con colisiones,
victoria, derrotas por tiempo/oxígeno, reinicio y conservación de herramientas
en modo remoto. También se verificaron E para recoger y Esc para pausar
mediante el teclado del navegador. La sesión remota con un servidor externo
no forma parte de esta prueba.
