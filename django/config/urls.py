from django.contrib import admin
from django.contrib.auth import views as auth_views
from django.urls import path

from core.views import guardar_ubicacion, home

urlpatterns = [
    path('login/', auth_views.LoginView.as_view(template_name='registration/login.html'), name='login'),
    path('logout/', auth_views.LogoutView.as_view(), name='logout'),
    path('', home, name='home'),
    path('guardar-ubicacion/', guardar_ubicacion, name='guardar_ubicacion'),
    path('admin/', admin.site.urls),
]
