from django.conf import settings
from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.shortcuts import redirect, render
from django.views.decorators.http import require_POST

from .models import Ubicacion


@login_required
def home(request):
    ubicaciones = Ubicacion.objects.filter(usuario=request.user)
    return render(
        request,
        'core/index.html',
        {
            'server_id': settings.SERVER_ID,
            'ubicaciones': ubicaciones,
        },
    )


@login_required
@require_POST
def guardar_ubicacion(request):
    latitud = request.POST.get('latitud')
    longitud = request.POST.get('longitud')

    if not latitud or not longitud:
        messages.error(request, 'No se recibieron coordenadas validas.')
        return redirect('home')

    try:
        latitud_float = float(latitud)
        longitud_float = float(longitud)
    except ValueError:
        messages.error(request, 'Las coordenadas deben ser numericas.')
        return redirect('home')

    if not (-90 <= latitud_float <= 90 and -180 <= longitud_float <= 180):
        messages.error(request, 'Las coordenadas estan fuera de rango.')
        return redirect('home')

    Ubicacion.objects.create(
        usuario=request.user,
        latitud=latitud_float,
        longitud=longitud_float,
    )
    messages.success(request, 'Ubicacion guardada correctamente.')
    return redirect('home')
