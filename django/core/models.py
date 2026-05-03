from django.db import models
from django.conf import settings


class Ubicacion(models.Model):
	id = models.AutoField(primary_key=True)
	usuario = models.ForeignKey(
		settings.AUTH_USER_MODEL,
		on_delete=models.CASCADE,
		related_name='ubicaciones',
	)
	latitud = models.DecimalField(max_digits=9, decimal_places=6)
	longitud = models.DecimalField(max_digits=9, decimal_places=6)
	fecha_hora = models.DateTimeField(auto_now_add=True)

	class Meta:
		ordering = ['-fecha_hora']

	def __str__(self):
		return f"{self.usuario.username} ({self.latitud}, {self.longitud})"
