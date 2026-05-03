from django.contrib import admin

from .models import Ubicacion


@admin.register(Ubicacion)
class UbicacionAdmin(admin.ModelAdmin):
    list_display = ('id', 'usuario', 'latitud', 'longitud', 'fecha_hora')
    list_filter = ('usuario', 'fecha_hora')
    search_fields = ('usuario__username',)
